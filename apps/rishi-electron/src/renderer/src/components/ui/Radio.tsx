import React from 'react'

interface RadioProps extends React.InputHTMLAttributes<HTMLInputElement> {
  label?: string
  value: string
  theme?: {
    background: string
    color: string
  }
}

export const Radio: React.FC<RadioProps> = ({ label, value, className = '', theme, ...props }) => {
  // Fallback chain: explicit reader theme color (set by reader pages that
  // override the OS theme) → app theme tokens via CSS variables. No raw
  // hex literals so dark mode tracks correctly.
  return (
    <label className="flex items-center cursor-pointer">
      <input
        type="radio"
        value={value}
        className={`w-4 h-4 border-border focus:ring-2 focus:ring-ring ${className}`}
        style={{
          accentColor: theme?.color ?? 'var(--primary)',
          borderColor: theme?.color ? `${theme.color}40` : 'var(--border)'
        }}
        {...props}
      />
      {label ? (
        <span className="ml-2 text-sm" style={{ color: theme?.color ?? 'var(--foreground)' }}>
          {label}
        </span>
      ) : null}
    </label>
  )
}

interface RadioGroupProps {
  children: React.ReactNode
  value?: string
  onChange?: (value: string) => void
  name?: string
  className?: string
  theme?: {
    background: string
    color: string
  }
}

export const RadioGroup: React.FC<RadioGroupProps> = ({
  children,
  value,
  onChange,
  name,
  className = '',
  theme
}) => {
  const handleChange = (event: React.ChangeEvent<HTMLInputElement>) => {
    onChange?.(event.target.value)
  }

  return (
    <div className={`space-y-2 ${className}`}>
      {React.Children.map(children, (child) => {
        if (React.isValidElement<RadioProps>(child) && child.type === Radio) {
          return React.cloneElement(child, {
            name,
            checked: value === child.props.value,
            onChange: handleChange,
            theme
          } as Partial<RadioProps>)
        }
        return child
      })}
    </div>
  )
}
