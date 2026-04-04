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
  return (
    <label className="flex items-center cursor-pointer">
      <input
        type="radio"
        value={value}
        className={`w-4 h-4 border-gray-300 focus:ring-2 ${className}`}
        style={{
          accentColor: theme?.color || '#2563eb',
          borderColor: theme?.color ? `${theme.color}40` : '#d1d5db'
        }}
        {...props}
      />
      {label && (
        <span className="ml-2 text-sm" style={{ color: theme?.color || '#374151' }}>
          {label}
        </span>
      )}
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
        if (React.isValidElement(child) && child.type === Radio) {
          return React.cloneElement(child, {
            name,
            checked: value === child.props.value,
            onChange: handleChange,
            theme
          })
        }
        return child
      })}
    </div>
  )
}
